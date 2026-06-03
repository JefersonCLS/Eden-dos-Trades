//+------------------------------------------------------------------+
//|                                              InsideBar_Robo.mq5  |
//|                                      Copyright 2026, Jeferson    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jeferson Santos"
#property version   "1.15"
#property strict

#include <Trade\Trade.mqh>

//--- ENUM para Escolha do Modo de Saída
enum ENUM_MODO_SAIDA {
   SAIDA_MEDIA_MOVEL = 0,  // Sair quando o preço cruzar a Média de 8
   SAIDA_ALVO_FIXO = 1     // Alvo 2x o Stop + Saída Parcial na metade do alvo
};

//+------------------------------------------------------------------+
//| PARÂMETROS DE ENTRADA                                            |
//+------------------------------------------------------------------+
input group "=== CONFIGURAÇÕES GERAIS ==="
input double   Volume_Operacao      = 0.1;   // Volume TOTAL da Operação (Lotes)
input ulong    Numero_Magico        = 123456;// Número Mágico (ID único do robô)
input string   Nome_Indicador       = "Inside Bar"; // Nome do arquivo do indicador (sem .ex5)
input int      Periodo_Media_Rapida = 8;     // Período da Média Rápida (Filtro e Saída)
input int      Periodo_Media_Lenta  = 80;    // Período da Média Lenta (Filtro de Tendência)

input group "=== ESTRATÉGIA DE SAÍDA ==="
input ENUM_MODO_SAIDA Modo_Saida       = SAIDA_ALVO_FIXO; // Escolha o Modo de Saída
input bool   Usar_Saida_Parcial  = true;  // (Modo Alvo Fixo) Ativar saída parcial?
input double Lotes_Saida_Parcial = 0.05;  // (Modo Alvo Fixo) Quantidade de lotes para sair na parcial

input group "=== GERENCIAMENTO DE RISCO (PAINEL) ==="
input double Meta_Lucro_Diario   = 200.0;  // Meta de ganho no dia (0 = Desativado)
input double Meta_Loss_Diario    = 0.0;    // Limite de perda no dia (0 = Desativado)
input double Meta_Lucro_Mensal   = 2000.0; // Meta de ganho no mês (0 = Desativado)
input double Meta_Loss_Mensal    = 0.0;    // Limite de perda no mês (0 = Desativado)

//+------------------------------------------------------------------+
//| VARIÁVEIS GLOBAIS                                                |
//+------------------------------------------------------------------+
CTrade trade;          
int    indicadorHandle; 
int    ma8Handle;       
int    ma80Handle;      
datetime ultimaBarraTime = 0; 

// Variáveis do Painel
string panelPrefix = "EdenDash_";

//+------------------------------------------------------------------+
//| Função de Inicialização                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Numero_Magico);
   trade.SetDeviationInPoints(10); 
   
   if(Modo_Saida == SAIDA_ALVO_FIXO && Usar_Saida_Parcial && Lotes_Saida_Parcial >= Volume_Operacao)
   {
      Print("⚠️ AVISO: 'Lotes_Saida_Parcial' deve ser MENOR que 'Volume_Operacao'.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // Carregar Indicador e Médias
   indicadorHandle = iCustom(_Symbol, _Period, Nome_Indicador, Periodo_Media_Rapida, Periodo_Media_Lenta, true);
   if(indicadorHandle == INVALID_HANDLE) return(INIT_FAILED);
   
   ma8Handle = iMA(_Symbol, _Period, Periodo_Media_Rapida, 0, MODE_EMA, PRICE_CLOSE);
   if(ma8Handle == INVALID_HANDLE) return(INIT_FAILED);

   ma80Handle = iMA(_Symbol, _Period, Periodo_Media_Lenta, 0, MODE_EMA, PRICE_CLOSE);
   if(ma80Handle == INVALID_HANDLE) return(INIT_FAILED);
   
   // Criar Painel
   CreateDashboard();
   
   Print("✅ Robô v1.15 Inicializado com Sucesso!");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Função de Desinicialização                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(indicadorHandle != INVALID_HANDLE) IndicatorRelease(indicadorHandle);
   if(ma8Handle != INVALID_HANDLE) IndicatorRelease(ma8Handle);
   if(ma80Handle != INVALID_HANDLE) IndicatorRelease(ma80Handle);
   
   DeleteDashboard();
}

//+------------------------------------------------------------------+
//| Função de Tick                                                   |
//+------------------------------------------------------------------+
void OnTick() 
{
   // 1. Atualizar Painel a cada tick (para mostrar P/L flutuante em tempo real)
   UpdateDashboard();

   // 2. Verificar Nova Barra
   datetime barraAtualTime = iTime(_Symbol, _Period, 0);
   bool ehNovaBarra = (barraAtualTime != ultimaBarraTime);
   if(ehNovaBarra) ultimaBarraTime = barraAtualTime;

   // 3. Gerenciar Posições Abertas (Saídas)
   if(PositionSelect(_Symbol))
   {
      if(PositionGetInteger(POSITION_MAGIC) == Numero_Magico)
      {
         long tipoPosicao = PositionGetInteger(POSITION_TYPE);
         double volumeAtual = PositionGetDouble(POSITION_VOLUME);
         double precoAbertura = PositionGetDouble(POSITION_PRICE_OPEN);
         double stopLoss = PositionGetDouble(POSITION_SL);
         double precoBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double precoAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         // --- SAÍDA POR CRUZAMENTO DE MÉDIA (Apenas na nova barra) ---
         if(ehNovaBarra && Modo_Saida == SAIDA_MEDIA_MOVEL)
         {
            double closeBuffer[], ma8Buffer[];
            ArraySetAsSeries(closeBuffer, true);
            ArraySetAsSeries(ma8Buffer, true);
            
            if(CopyClose(_Symbol, _Period, 0, 1, closeBuffer) > 0 && CopyBuffer(ma8Handle, 0, 0, 1, ma8Buffer) > 0)
            {
               double closeAtual = closeBuffer[0];
               double ma8Atual = ma8Buffer[0];

               if((tipoPosicao == POSITION_TYPE_BUY && closeAtual < ma8Atual) || 
                  (tipoPosicao == POSITION_TYPE_SELL && closeAtual > ma8Atual))
               {
                  trade.PositionClose(_Symbol);
               }
            }
         }

         // --- SAÍDA PARCIAL (A cada tick) ---
         if(Modo_Saida == SAIDA_ALVO_FIXO && Usar_Saida_Parcial)
         {
            // Verifica se a parcial ainda não foi feita (volume ainda é o total)
            if(MathAbs(volumeAtual - Volume_Operacao) < 0.0001) 
            {
               double distanciaRisco = MathAbs(precoAbertura - stopLoss);
               double alvoParcial = 0;
               bool atingiuParcial = false;

               if(tipoPosicao == POSITION_TYPE_BUY)
               {
                  alvoParcial = precoAbertura + distanciaRisco;
                  if(precoBid >= alvoParcial) atingiuParcial = true;
               }
               else if(tipoPosicao == POSITION_TYPE_SELL)
               {
                  alvoParcial = precoAbertura - distanciaRisco;
                  if(precoAsk <= alvoParcial) atingiuParcial = true;
               }

               if(atingiuParcial)
               {
                  trade.PositionClosePartial(_Symbol, Lotes_Saida_Parcial);
               }
            }
         }
      }
   }

   // 4. Lógica de Entrada (Apenas na nova barra e se puder operar)
   if(ehNovaBarra && PodeOperar())
   {
      // Verificar se já existe posição aberta deste robô
      bool temPosicao = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Numero_Magico)
         {
            temPosicao = true;
            break;
         }
      }

      if(!temPosicao)
      {
         double colorBuffer[], openBuffer[], closeBuffer[], highBuffer[], lowBuffer[], ma8Buffer[], ma80Buffer[];
         ArraySetAsSeries(colorBuffer, true);
         ArraySetAsSeries(openBuffer, true);
         ArraySetAsSeries(closeBuffer, true);
         ArraySetAsSeries(highBuffer, true);
         ArraySetAsSeries(lowBuffer, true);
         ArraySetAsSeries(ma8Buffer, true);
         ArraySetAsSeries(ma80Buffer, true);

         // Copiar dados: Index 0 = Vela Atual (Confirmação), Index 1 = Vela Anterior (Sinal)
         if(CopyBuffer(indicadorHandle, 4, 0, 2, colorBuffer) <= 0) return;
         if(CopyOpen(_Symbol, _Period, 0, 2, openBuffer) <= 0) return;
         if(CopyClose(_Symbol, _Period, 0, 2, closeBuffer) <= 0) return;
         if(CopyHigh(_Symbol, _Period, 0, 2, highBuffer) <= 0) return;
         if(CopyLow(_Symbol, _Period, 0, 2, lowBuffer) <= 0) return;
         if(CopyBuffer(ma8Handle, 0, 0, 2, ma8Buffer) <= 0) return;
         if(CopyBuffer(ma80Handle, 0, 0, 2, ma80Buffer) <= 0) return;

         // Dados da Vela de Sinal (Index 1)
         double sigColor = colorBuffer[1];
         double sigLow   = lowBuffer[1];
         double sigHigh  = highBuffer[1];
         
         // Dados da Vela de Confirmação (Index 0)
         double confOpen  = openBuffer[0];
         double confClose = closeBuffer[0];
         
         // Dados das Médias
         double ma8_curr  = ma8Buffer[0];
         double ma8_prev  = ma8Buffer[1];
         double ma80_curr = ma80Buffer[0];
         double ma80_prev = ma80Buffer[1];

         // --- CONDIÇÃO DE COMPRA ---
         bool condicaoCompra = (sigColor == 0.0) && 
                               (ma8_curr > ma8_prev) && (ma80_curr > ma80_prev) && (ma8_curr > ma80_curr) &&
                               (sigLow > ma8_curr) && (sigLow > ma80_curr) &&
                               (confOpen > ma8_curr) && (confClose > ma8_curr) &&
                               (confOpen > ma80_curr) && (confClose > ma80_curr) &&
                               (confClose > sigHigh);

         // --- CONDIÇÃO DE VENDA ---
         bool condicaoVenda  = (sigColor == 1.0) && 
                               (ma8_curr < ma8_prev) && (ma80_curr < ma80_prev) && (ma8_curr < ma80_curr) &&
                               (sigHigh < ma8_curr) && (sigHigh < ma80_curr) &&
                               (confOpen < ma8_curr) && (confClose < ma8_curr) &&
                               (confOpen < ma80_curr) && (confClose < ma80_curr) &&
                               (confClose < sigLow);

         if(condicaoCompra)
         {
            double sl = NormalizeDouble(sigLow, _Digits);
            double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double tp = 0;
            
            if(Modo_Saida == SAIDA_ALVO_FIXO)
               tp = NormalizeDouble(entry + (MathAbs(entry - sl) * 2.0), _Digits);

            if(trade.Buy(Volume_Operacao, _Symbol, entry, sl, tp, "Eden Compra"))
            {
               Print("✅ COMPRA executada. SL: ", sl, " | TP: ", (tp>0?tp:"Média 8"));
            }
         }
         else if(condicaoVenda)
         {
            double sl = NormalizeDouble(sigHigh, _Digits);
            double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double tp = 0;
            
            if(Modo_Saida == SAIDA_ALVO_FIXO)
               tp = NormalizeDouble(entry - (MathAbs(entry - sl) * 2.0), _Digits);

            if(trade.Sell(Volume_Operacao, _Symbol, entry, sl, tp, "Eden Venda"))
            {
               Print("✅ VENDA executada. SL: ", sl, " | TP: ", (tp>0?tp:"Média 8"));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| FUNÇÃO: Verifica Limites de Risco Diário/Mensal                  |
//+------------------------------------------------------------------+
bool PodeOperar()
{
   double plDia = 0, plMes = 0;
   int winsDia = 0, lossDia = 0, winsMes = 0, lossMes = 0;
   
   GetPeriodStats(TimeCurrent(), 1, plDia, winsDia, lossDia);   // 1 = Diário
   GetPeriodStats(TimeCurrent(), 2, plMes, winsMes, lossMes);   // 2 = Mensal

   if(Meta_Lucro_Diario > 0 && plDia >= Meta_Lucro_Diario) return false;
   if(Meta_Loss_Diario > 0 && plDia <= -Meta_Loss_Diario) return false;
   if(Meta_Lucro_Mensal > 0 && plMes >= Meta_Lucro_Mensal) return false;
   if(Meta_Loss_Mensal > 0 && plMes <= -Meta_Loss_Mensal) return false;

   return true;
}

//+------------------------------------------------------------------+
//| FUNÇÃO: Calcula Estatísticas de um Período                       |
//+------------------------------------------------------------------+
void GetPeriodStats(datetime agora, int periodo, double &pl, int &wins, int &losses)
{
   pl = 0; wins = 0; losses = 0;
   datetime inicio = agora;
   
   MqlDateTime dt; TimeToStruct(agora, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   
   if(periodo == 1) { // Diário
      inicio = StructToTime(dt);
   } else if(periodo == 2) { // Mensal
      dt.day = 1;
      inicio = StructToTime(dt);
   }

   if(HistorySelect(inicio, agora))
   {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == Numero_Magico && 
            HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            double lucro = HistoryDealGetDouble(ticket, DEAL_PROFIT) + 
                           HistoryDealGetDouble(ticket, DEAL_SWAP) + 
                           HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            pl += lucro;
            if(lucro > 0) wins++;
            else if(lucro < 0) losses++;
         }
      }
   }
   
   // Soma P/L Flutuante das posições abertas
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Numero_Magico)
      {
         pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
}

//+------------------------------------------------------------------+
//| FUNÇÕES DO PAINEL (DASHBOARD)                                    |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   int x = 15, y = 15, w = 320, h = 240;
   
   // Fundo - Estilo Moderno Roxo Escuro
   ObjectCreate(0, panelPrefix+"BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_XSIZE, w);
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_YSIZE, h);
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_BGCOLOR, C'30,0,50'); // Roxo muito escuro
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_COLOR, C'138,43,226'); // Borda BlueViolet
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_CORNER, CORNER_LEFT_UPPER); // Lado ESQUERDO
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_BACK, true);
   ObjectSetInteger(0, panelPrefix+"BG", OBJPROP_SELECTABLE, false);

   // Título
   CreateLabel(panelPrefix+"Title", x+10, y+10, "EDEN DOS TRADES v1.15", C'230,230,250', 10, CORNER_LEFT_UPPER, true); // Lavender
   
   // Cabeçalhos de Coluna - Roxo Claro
   CreateLabel(panelPrefix+"Col_Day", x+10, y+35, "HOJE", C'186,85,211', 9, CORNER_LEFT_UPPER, true); // MediumOrchid
   CreateLabel(panelPrefix+"Col_Week", x+110, y+35, "SEMANA", C'186,85,211', 9, CORNER_LEFT_UPPER, true);
   CreateLabel(panelPrefix+"Col_Month", x+220, y+35, "MÊS", C'186,85,211', 9, CORNER_LEFT_UPPER, true);

   // Linhas Divisórias - Roxo
   CreateLine(panelPrefix+"L1", x+10, y+60, w-20, C'138,43,226'); // BlueViolet
   CreateLine(panelPrefix+"L2", x+10, y+100, w-20, C'138,43,226');
   CreateLine(panelPrefix+"L3", x+10, y+140, w-20, C'138,43,226');
   CreateLine(panelPrefix+"L4", x+10, y+180, w-20, C'138,43,226');

   // Rótulos das Linhas (Esquerda) - Tom suave
   CreateLabel(panelPrefix+"Lbl_PL", x+10, y+70, "Lucro / Perda:", C'216,191,216', 8, CORNER_LEFT_UPPER, false); // Thistle
   CreateLabel(panelPrefix+"Lbl_Win", x+10, y+110, "Trades Positivos:", C'216,191,216', 8, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Lbl_Loss", x+10, y+150, "Trades Negativos:", C'216,191,216', 8, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Lbl_Tot", x+10, y+190, "Total de Trades:", C'216,191,216', 8, CORNER_LEFT_UPPER, false);

   // Valores (Serão atualizados dinamicamente)
   CreateLabel(panelPrefix+"Val_PL_Day", x+10, y+70, "$0.00", clrWhite, 9, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Val_PL_Week", x+110, y+70, "$0.00", clrWhite, 9, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Val_PL_Month", x+220, y+70, "$0.00", clrWhite, 9, CORNER_LEFT_UPPER, false);

   CreateLabel(panelPrefix+"Val_Win_Day", x+10, y+110, "0", clrLime, 9, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Val_Win_Week", x+110, y+110, "0", clrLime, 9, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Val_Win_Month", x+220, y+110, "0", clrLime, 9, CORNER_LEFT_UPPER, false);

   CreateLabel(panelPrefix+"Val_Loss_Day", x+10, y+150, "0", clrRed, 9, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Val_Loss_Week", x+110, y+150, "0", clrRed, 9, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Val_Loss_Month", x+220, y+150, "0", clrRed, 9, CORNER_LEFT_UPPER, false);

   CreateLabel(panelPrefix+"Val_Tot_Day", x+10, y+190, "0", clrWhite, 9, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Val_Tot_Week", x+110, y+190, "0", clrWhite, 9, CORNER_LEFT_UPPER, false);
   CreateLabel(panelPrefix+"Val_Tot_Month", x+220, y+190, "0", clrWhite, 9, CORNER_LEFT_UPPER, false);

   // Status da Operação (Rodapé)
   CreateLabel(panelPrefix+"Status", x+10, y+215, "Status: Aguardando Sinal...", clrYellow, 8, CORNER_LEFT_UPPER, false);
   
   ChartRedraw();
}

void UpdateDashboard()
{
   datetime agora = TimeCurrent();
   double plDia=0, plSem=0, plMes=0;
   int winDia=0, lossDia=0, winSem=0, lossSem=0, winMes=0, lossMes=0;

   GetPeriodStats(agora, 1, plDia, winDia, lossDia);
   
   // Cálculo Semanal (Simplificado: diferença entre hoje e 7 dias atrás)
   datetime seteDiasAtras = agora - (7 * 24 * 60 * 60);
   double plSemanaTotal=0; int winSemanaTotal=0, lossSemanaTotal=0;
   GetPeriodStats(seteDiasAtras, 1, plSemanaTotal, winSemanaTotal, lossSemanaTotal);
   plSem = plSemanaTotal; winSem = winSemanaTotal; lossSem = lossSemanaTotal;

   GetPeriodStats(agora, 2, plMes, winMes, lossMes);

   // Atualizar Textos e Cores
   UpdateLabel(panelPrefix+"Val_PL_Day", FormatMoney(plDia), GetColor(plDia));
   UpdateLabel(panelPrefix+"Val_PL_Week", FormatMoney(plSem), GetColor(plSem));
   UpdateLabel(panelPrefix+"Val_PL_Month", FormatMoney(plMes), GetColor(plMes));

   UpdateLabel(panelPrefix+"Val_Win_Day", IntegerToString(winDia), clrLime);
   UpdateLabel(panelPrefix+"Val_Win_Week", IntegerToString(winSem), clrLime);
   UpdateLabel(panelPrefix+"Val_Win_Month", IntegerToString(winMes), clrLime);

   UpdateLabel(panelPrefix+"Val_Loss_Day", IntegerToString(lossDia), clrRed);
   UpdateLabel(panelPrefix+"Val_Loss_Week", IntegerToString(lossSem), clrRed);
   UpdateLabel(panelPrefix+"Val_Loss_Month", IntegerToString(lossMes), clrRed);

   UpdateLabel(panelPrefix+"Val_Tot_Day", IntegerToString(winDia + lossDia), clrWhite);
   UpdateLabel(panelPrefix+"Val_Tot_Week", IntegerToString(winSem + lossSem), clrWhite);
   UpdateLabel(panelPrefix+"Val_Tot_Month", IntegerToString(winMes + lossMes), clrWhite);

   // Status
   string statusText = "Status: Aguardando Sinal...";
   color statusColor = clrYellow;
   
   if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == Numero_Magico)
   {
      double openPL = PositionGetDouble(POSITION_PROFIT);
      statusText = "EM OPERAÇÃO | P/L Aberto: " + FormatMoney(openPL);
      statusColor = (openPL >= 0) ? clrLime : clrRed;
   }
   else if(!PodeOperar())
   {
      statusText = "Status: META ATINGIDA (Standby)";
      statusColor = clrOrange;
   }
   
   UpdateLabel(panelPrefix+"Status", statusText, statusColor);
}

void DeleteDashboard()
{
   int total = ObjectsTotal(0, 0, OBJ_LABEL);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, OBJ_LABEL);
      if(StringFind(name, panelPrefix) == 0) ObjectDelete(0, name);
   }
   total = ObjectsTotal(0, 0, OBJ_RECTANGLE_LABEL);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, OBJ_RECTANGLE_LABEL);
      if(StringFind(name, panelPrefix) == 0) ObjectDelete(0, name);
   }
   ChartRedraw();
}

//--- Funções Auxiliares do Painel ---
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, ENUM_BASE_CORNER corner, bool isBold)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, isBold ? "Arial Bold" : "Arial");
}

void UpdateLabel(string name, string text, color clr)
{
   if(ObjectGetString(0, name, OBJPROP_TEXT) != text)
      ObjectSetString(0, name, OBJPROP_TEXT, text);
   if(ObjectGetInteger(0, name, OBJPROP_COLOR) != clr)
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void CreateLine(string name, int x, int y, int width, color clr)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
}

string FormatMoney(double value)
{
   return (value >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(value), 2);
}

color GetColor(double value)
{
   if(value > 0) return clrLime;
   if(value < 0) return clrRed;
   return clrWhite;
}
//+------------------------------------------------------------------+
